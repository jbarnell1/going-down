// The instrument in the player's hand: an olive field recorder with a big VU-style needle meter, a
// smoked tape window with two reels and a red lamp, held low in the bottom right of the view in a
// dark rubber glove. Built from boxes and planes with textures painted in code, drawn into the tape
// target after the world (its own little scene and camera, depth cleared first so it never sinks into
// a wall), so it goes through the tape look like everything else.
//
// It never prints the rule. It shows the logic's needle state by how the needle behaves:
//   idle      the needle lies dead still on its left peg, lamp dark;
//   dormant   the needle twitches nervously just off the peg, harder the closer something is, and
//             the lamp glimmers: something is near, nothing is going onto the tape;
//   recording the needle swings and climbs toward the red as the reading grows, kicking on every
//             tick; the lamp burns; the reels turn.
// The only words it ever shows are on the paper slip it prints, once per run.

import * as THREE from 'three';
import type { Needle } from '../sim/instrument';
import { drawText, textWidth } from './pixelFont';

// ------------------------------------------------------------------------------------------------
// Tuning.

/** Overlay camera field of view (degrees) and how far in front of it the device is held. */
const FOV = 40;
const HOLD_DIST = 0.6;
/** Device body size, metres: width, height, depth. */
const BODY_W = 0.2;
const BODY_H = 0.15;
const BODY_D = 0.06;
/** Faceplate texture size in texels (1 texel = 1.25 mm). */
const TEX_W = 160;
const TEX_H = 120;
/** Where the device sits when raised: its right edge as a fraction of the half-width of the view at
 * HOLD_DIST (clear of the camcorder display's right-hand column), and its centre as a fraction of the
 * half-height down. On a phone the right thumb sits on the raise button in the corner, so there the
 * device is held nearer the middle, where no thumb covers the dial. */
const RIGHT_EDGE = 0.66;
const RIGHT_EDGE_TOUCH = 0.46;
const HOLD_Y = 0.62;
/** Overall size of the device in the view. */
const HOLD_SCALE = 0.9;
const HOLD_SCALE_TOUCH = 0.85;
/** Tilt toward the eye (radians): face up, turned in toward the centre, a slight roll. */
const TILT_X = -0.32;
const TILT_Y = -0.3;
const TILT_Z = 0.05;
/** Raise and lower times (seconds, smoothing time constants). */
const RAISE_TAU = 0.09;
const LOWER_TAU = 0.07;
/** Needle sweep: rest angle and full scale, degrees from vertical (negative is left). */
const NEEDLE_REST = -47;
const NEEDLE_FULL = 47;
/** Needle spring: stiffness (1/s^2) and damping ratio (below 1 overshoots like a real meter). */
const NEEDLE_K = 260;
const NEEDLE_ZETA = 0.42;
/** Recording: the swing's size in degrees at the start and near full, and the kick per tick. */
const SWING_MIN = 3;
const SWING_MAX = 7;
const TICK_KICK = 5;
/** Reading value at which the needle has climbed 63% of the way (matches the ticking's curve). */
const CLIMB_SCALE = 120;
/** Dormant twitch: offset off the peg and jitter size in degrees, far (16 m) and near. */
const TWITCH_OFFSET = 5;
const TWITCH_FAR = 2;
const TWITCH_NEAR = 9;
/** Reel speed while recording, radians per second per tick-per-second. */
const REEL_RATE = 0.9;
/** The slip: seconds to print, to stay up, to fall away. */
const SLIP_PRINT = 1.1;
const SLIP_HOLD = 5.5;
const SLIP_FALL = 0.6;

const DEG = Math.PI / 180;

// ------------------------------------------------------------------------------------------------
// Textures.

function canvasTex(w: number, h: number, paint: (g: CanvasRenderingContext2D) => void): THREE.CanvasTexture {
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const g = c.getContext('2d');
  if (g) paint(g);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.SRGBColorSpace;
  t.magFilter = THREE.NearestFilter;
  t.minFilter = THREE.NearestFilter;
  t.generateMipmaps = false;
  return t;
}

/** Texture pixel (top-left origin) to the face's local metres (centre origin, y up). */
function fx(px: number): number {
  return (px / TEX_W - 0.5) * BODY_W;
}
function fy(py: number): number {
  return (0.5 - py / TEX_H) * BODY_H;
}

const PIVOT = { x: 80, y: 76 };
const SCALE_R = 56;
const REELS = [{ x: 56, y: 97 }, { x: 104, y: 97 }];
const REEL_R = 12;
const LAMP = { x: 140, y: 97 };

function speckle(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, base: [number, number, number], amp: number, seed: number): void {
  let s = seed;
  for (let j = y; j < y + h; j++) {
    for (let i = x; i < x + w; i++) {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      const n = ((s >> 8) % 1000) / 1000 - 0.5;
      g.fillStyle = `rgb(${base[0] + n * amp},${base[1] + n * amp},${base[2] + n * amp})`;
      g.fillRect(i, j, 1, 1);
    }
  }
}

function faceTexture(): THREE.CanvasTexture {
  return canvasTex(TEX_W, TEX_H, (g) => {
    // Olive enamel, a little worn.
    speckle(g, 0, 0, TEX_W, TEX_H, [118, 122, 98], 14, 7);
    g.fillStyle = '#5c604c';
    g.fillRect(0, 0, TEX_W, 2);
    g.fillRect(0, TEX_H - 2, TEX_W, 2);
    g.fillRect(0, 0, 2, TEX_H);
    g.fillRect(TEX_W - 2, 0, 2, TEX_H);
    // Screws.
    for (const [x, y] of [[6, 6], [TEX_W - 8, 6], [6, TEX_H - 8], [TEX_W - 8, TEX_H - 8]] as const) {
      g.fillStyle = '#3d4034';
      g.fillRect(x, y, 3, 3);
      g.fillStyle = '#a7aa94';
      g.fillRect(x + 1, y, 1, 3);
    }
    // Meter window: black bezel, cream face.
    g.fillStyle = '#1b1d18';
    g.fillRect(9, 7, 142, 60);
    g.fillStyle = '#efe6c8';
    g.fillRect(11, 9, 138, 56);
    // Scale arc with ticks, the last stretch in red.
    const arc = (from: number, to: number, r: number, colour: string, width: number): void => {
      g.strokeStyle = colour;
      g.lineWidth = width;
      g.beginPath();
      g.arc(PIVOT.x, PIVOT.y, r, (-90 + from) * DEG, (-90 + to) * DEG);
      g.stroke();
    };
    arc(NEEDLE_REST, 20, SCALE_R, '#1b1d18', 1.5);
    arc(20, NEEDLE_FULL, SCALE_R, '#c42a1e', 3.5);
    for (let a = NEEDLE_REST; a <= NEEDLE_FULL + 0.01; a += (NEEDLE_FULL - NEEDLE_REST) / 10) {
      const big = Math.round((a - NEEDLE_REST) / ((NEEDLE_FULL - NEEDLE_REST) / 10)) % 5 === 0;
      const r0 = SCALE_R + 1;
      const r1 = SCALE_R + (big ? 8 : 5);
      g.strokeStyle = a > 20 ? '#c42a1e' : '#1b1d18';
      g.lineWidth = big ? 2 : 1;
      g.beginPath();
      g.moveTo(PIVOT.x + Math.sin(a * DEG) * r0, PIVOT.y - Math.cos(a * DEG) * r0);
      g.lineTo(PIVOT.x + Math.sin(a * DEG) * r1, PIVOT.y - Math.cos(a * DEG) * r1);
      g.stroke();
    }
    // The rest peg, bottom left of the face.
    g.fillStyle = '#1b1d18';
    g.fillRect(PIVOT.x + Math.sin(NEEDLE_REST * DEG) * 44 - 3, PIVOT.y - Math.cos(NEEDLE_REST * DEG) * 44 - 2, 3, 3);
    // Bezel strip over the pivot.
    g.fillStyle = '#2a2c25';
    g.fillRect(9, 66, 142, 4);
    // Tape window.
    g.fillStyle = '#1b1d18';
    g.fillRect(28, 80, 104, 34);
    g.fillStyle = '#2c2a26';
    g.fillRect(30, 82, 100, 30);
    g.fillStyle = '#3e3a33';
    g.fillRect(30, 82, 100, 3);
    // Tape between the reels.
    g.fillStyle = '#4a3324';
    g.fillRect(REELS[0]!.x, REELS[0]!.y + REEL_R - 2, REELS[1]!.x - REELS[0]!.x, 2);
    // Lamp bezel.
    g.fillStyle = '#1b1d18';
    g.fillRect(LAMP.x - 5, LAMP.y - 5, 10, 10);
  });
}

function reelTexture(): THREE.CanvasTexture {
  const n = 32;
  return canvasTex(n, n, (g) => {
    const c = n / 2;
    g.clearRect(0, 0, n, n);
    // Wound tape.
    g.fillStyle = '#5a3d29';
    g.beginPath();
    g.arc(c, c, c - 1, 0, Math.PI * 2);
    g.fill();
    // Hub.
    g.fillStyle = '#e8e4d8';
    g.beginPath();
    g.arc(c, c, c * 0.5, 0, Math.PI * 2);
    g.fill();
    g.fillStyle = '#1b1d18';
    for (let k = 0; k < 3; k++) {
      const a = (k * Math.PI * 2) / 3;
      g.save();
      g.translate(c, c);
      g.rotate(a);
      g.fillRect(-1.5, -c * 0.46, 3, c * 0.3);
      g.restore();
    }
    g.beginPath();
    g.arc(c, c, 2.5, 0, Math.PI * 2);
    g.fill();
  });
}

/** The slip's paper with its lines of text, 1 texel = 1 font pixel. */
function slipTexture(lines: readonly string[]): { tex: THREE.CanvasTexture; w: number; h: number } {
  const margin = 5;
  const w = Math.max(...lines.map(textWidth)) + margin * 2;
  const h = lines.length * 11 - 4 + margin * 2 + 3;
  const tex = canvasTex(w, h, (g) => {
    speckle(g, 0, 0, w, h, [238, 235, 222], 10, 3);
    // Perforated top edge where it tore from the roll.
    g.fillStyle = '#b9b5a5';
    for (let x = 0; x < w; x += 3) g.fillRect(x, 0, 2, 1);
    g.fillStyle = '#26231f';
    lines.forEach((line, i) => drawText(g, line, margin, margin + 3 + i * 11));
  });
  return { tex, w, h };
}

/** Splits slip text into at most two lines at its colon (the words are kept exactly). */
function slipLines(text: string): string[] {
  const i = text.indexOf(': ');
  return i > 0 ? [text.slice(0, i + 1), text.slice(i + 2)] : [text];
}

// ------------------------------------------------------------------------------------------------

export interface InstrumentFrame {
  raised: boolean;
  needle: Needle;
  /** Value of the open reading (0 if none). */
  value: number;
  /** Distance to the nearest entity (null if none). */
  distance: number | null;
  tickHz: number;
  /** Audible ticks since the last frame. */
  ticks: number;
  /** The holder's walking speed, m/s (for the sway). */
  walkSpeed: number;
}

export class InstrumentView {
  readonly scene = new THREE.Scene();
  readonly camera = new THREE.PerspectiveCamera(FOV, 16 / 9, 0.05, 5);
  private readonly root = new THREE.Group();
  private readonly device = new THREE.Group();
  private readonly needlePivot = new THREE.Group();
  private readonly reels: THREE.Mesh[] = [];
  private readonly lampMat: THREE.MeshBasicMaterial;
  private readonly slipGroup = new THREE.Group();
  private slipMesh: THREE.Mesh | null = null;
  private slipH = 0;
  private raise = 0;
  private angle = NEEDLE_REST;
  private angVel = 0;
  private twitchTarget = 0;
  private twitchIn = 0;
  private reelAngle = 0;
  private sway = 0;
  private time = 0;
  private slipAt = -1;
  private touchLayout = false;
  /** The text of the slip last printed, and whether it is up now. For tests. */
  slipText = '';

  constructor() {
    this.scene.add(new THREE.HemisphereLight(0xfffcf2, 0x6d7266, 1.9));
    const sun = new THREE.DirectionalLight(0xffffff, 1.4);
    sun.position.set(0.3, 1, 0.6);
    this.scene.add(sun);
    this.scene.add(this.root);
    this.root.add(this.device);

    // The case.
    const side = new THREE.MeshLambertMaterial({ color: 0x6e7259 });
    const top = new THREE.MeshLambertMaterial({ color: 0x7d8166 });
    const face = new THREE.MeshLambertMaterial({ map: faceTexture() });
    const box = new THREE.Mesh(new THREE.BoxGeometry(BODY_W, BODY_H, BODY_D), [side, side, top, side, face, side]);
    this.device.add(box);
    // A slot along the top for the slip.
    const slot = new THREE.Mesh(new THREE.BoxGeometry(BODY_W * 0.8, 0.002, 0.008), new THREE.MeshBasicMaterial({ color: 0x14150f }));
    slot.position.set(0, BODY_H / 2 + 0.0005, -0.006);
    this.device.add(slot);
    // A stubby aerial post on the left shoulder.
    const post = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.008, 0.035, 6), new THREE.MeshLambertMaterial({ color: 0x2c2e27 }));
    post.position.set(-BODY_W / 2 + 0.015, BODY_H / 2 + 0.017, -0.012);
    this.device.add(post);

    const zFace = BODY_D / 2;
    // Needle: a thin dark bar from the pivot, with a cap over its root.
    const len = (SCALE_R - 3) / TEX_W * BODY_W;
    const needle = new THREE.Mesh(new THREE.BoxGeometry(0.0028, len, 0.001), new THREE.MeshBasicMaterial({ color: 0x15130f }));
    needle.position.y = len / 2;
    this.needlePivot.add(needle);
    const tip = new THREE.Mesh(new THREE.BoxGeometry(0.0028, len * 0.25, 0.0012), new THREE.MeshBasicMaterial({ color: 0xa8231a }));
    tip.position.y = len * 0.86;
    this.needlePivot.add(tip);
    this.needlePivot.position.set(fx(PIVOT.x), fy(PIVOT.y), zFace + 0.0015);
    this.device.add(this.needlePivot);
    const cap = new THREE.Mesh(new THREE.CylinderGeometry(0.006, 0.006, 0.004, 10).rotateX(Math.PI / 2), new THREE.MeshLambertMaterial({ color: 0x24261f }));
    cap.position.set(fx(PIVOT.x), fy(PIVOT.y), zFace + 0.002);
    this.device.add(cap);

    // Reels.
    const reelTex = reelTexture();
    for (const r of REELS) {
      const m = new THREE.Mesh(
        new THREE.PlaneGeometry((REEL_R * 2) / TEX_W * BODY_W, (REEL_R * 2) / TEX_H * BODY_H),
        new THREE.MeshLambertMaterial({ map: reelTex, alphaTest: 0.5 }),
      );
      m.position.set(fx(r.x), fy(r.y), zFace + 0.001);
      this.device.add(m);
      this.reels.push(m);
    }

    // Lamp.
    this.lampMat = new THREE.MeshBasicMaterial({ color: 0x3a0d0a });
    const lamp = new THREE.Mesh(new THREE.BoxGeometry(0.008, 0.006, 0.004), this.lampMat);
    lamp.position.set(fx(LAMP.x), fy(LAMP.y), zFace + 0.002);
    this.device.add(lamp);

    // The glove holding it from below on the right, and the sleeve running off the frame.
    const rubber = new THREE.MeshLambertMaterial({ color: 0x2f3431 });
    const palm = new THREE.Mesh(new THREE.BoxGeometry(0.075, 0.07, 0.075), rubber);
    palm.position.set(BODY_W / 2 - 0.025, -BODY_H / 2 - 0.022, -0.004);
    this.device.add(palm);
    const thumb = new THREE.Mesh(new THREE.BoxGeometry(0.022, 0.055, 0.024), rubber);
    thumb.position.set(BODY_W / 2 + 0.006, -BODY_H / 2 + 0.03, 0.022);
    thumb.rotation.z = -0.25;
    this.device.add(thumb);
    const fingers = new THREE.Mesh(new THREE.BoxGeometry(0.06, 0.03, 0.02), rubber);
    fingers.position.set(BODY_W / 2 - 0.03, -BODY_H / 2 + 0.004, BODY_D / 2 + 0.006);
    this.device.add(fingers);
    const sleeve = new THREE.Mesh(new THREE.CylinderGeometry(0.05, 0.06, 0.3, 8), new THREE.MeshLambertMaterial({ color: 0x8f969a }));
    sleeve.position.set(BODY_W / 2, -BODY_H / 2 - 0.2, 0.02);
    sleeve.rotation.z = 0.35;
    sleeve.rotation.x = 0.5;
    this.device.add(sleeve);

    // The slip rises from the slot, inside the case until printed.
    this.slipGroup.position.set(0, BODY_H / 2, -0.006);
    this.device.add(this.slipGroup);

    this.root.visible = false;
  }

  /** True while any part of it could be on screen (the world pass skips it otherwise). */
  get visible(): boolean {
    return this.root.visible;
  }

  /** How far raised it is, 0..1. */
  get raisedAmount(): number {
    return this.raise;
  }

  /** The slip is up (printing or readable). */
  get slipShown(): boolean {
    return this.slipAt >= 0 && this.time - this.slipAt < SLIP_PRINT + SLIP_HOLD;
  }

  /** The needle's drawn angle in degrees from vertical (negative is left). For tests. */
  get needleAngle(): number {
    return this.angle;
  }

  /** Phone layout: held nearer the middle, clear of the thumb on the raise button. */
  setTouchLayout(touch: boolean): void {
    this.touchLayout = touch;
  }

  setAspect(aspect: number): void {
    this.camera.aspect = aspect;
    this.camera.updateProjectionMatrix();
  }

  /** Prints the slip with exactly this text. */
  printSlip(text: string): void {
    this.slipText = text;
    if (this.slipMesh) {
      this.slipGroup.remove(this.slipMesh);
      this.slipMesh.geometry.dispose();
      (this.slipMesh.material as THREE.MeshBasicMaterial).map?.dispose();
    }
    const { tex, w, h } = slipTexture(slipLines(text));
    // Slightly wider than the case, so each font pixel lands on at least one picture line.
    const width = BODY_W * 1.05;
    this.slipH = (width * h) / w;
    const geo = new THREE.PlaneGeometry(width, this.slipH).translate(0, this.slipH / 2, 0);
    this.slipMesh = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({ map: tex, color: 0xd8d6cc, side: THREE.DoubleSide }));
    this.slipGroup.add(this.slipMesh);
    this.slipAt = this.time;
  }

  update(dt: number, f: InstrumentFrame): void {
    this.time += dt;
    const want = f.raised ? 1 : 0;
    this.raise += (want - this.raise) * (1 - Math.exp(-dt / (want > this.raise ? RAISE_TAU : LOWER_TAU)));
    if (Math.abs(want - this.raise) < 0.002) this.raise = want;
    this.root.visible = this.raise > 0.002;

    this.updateNeedle(dt, f);
    this.updateSlip();
    if (!this.root.visible) return;

    // Hold position from the view's size, so it sits the same on any screen shape.
    const halfH = Math.tan((FOV / 2) * DEG) * HOLD_DIST;
    const halfW = halfH * this.camera.aspect;
    const scale = this.touchLayout ? HOLD_SCALE_TOUCH : HOLD_SCALE;
    this.root.scale.setScalar(scale);
    // The case and glove reach about 0.58 of the body's width right of its centre once turned in.
    const reach = BODY_W * 0.58 * scale;
    // On narrow (portrait) screens it may not fit beside the centre: then it keeps inside the frame.
    const x = Math.max(-halfW + reach, halfW * (this.touchLayout ? RIGHT_EDGE_TOUCH : RIGHT_EDGE) - reach);
    const yUp = -halfH * HOLD_Y;
    const yDown = -halfH - BODY_H * 1.4;
    const e = 1 - (1 - this.raise) ** 3;
    this.sway += dt * (4 + f.walkSpeed * 2.4);
    const bob = Math.min(1, f.walkSpeed / 3);
    this.root.position.set(x + Math.sin(this.sway) * 0.004 * bob, yDown + (yUp - yDown) * e + Math.abs(Math.cos(this.sway)) * 0.006 * bob, -HOLD_DIST);
    this.device.rotation.set(TILT_X + (1 - e) * 0.5, TILT_Y, TILT_Z + Math.sin(this.sway * 0.5) * 0.01 * bob);

    const lit = f.needle === 'recording' ? (f.ticks > 0 ? 1 : 0.75) : f.needle === 'dormant' ? 0.12 + 0.12 * Math.random() : 0;
    this.lampMat.color.setRGB(0.23 + lit * 3.2, 0.05 + lit * 0.35, 0.04 + lit * 0.25);

    if (f.needle === 'recording') this.reelAngle -= dt * REEL_RATE * Math.max(3, f.tickHz);
    this.reels.forEach((r, i) => { r.rotation.z = this.reelAngle * (i === 0 ? 1 : 1.25); });
  }

  private updateNeedle(dt: number, f: InstrumentFrame): void {
    let target = NEEDLE_REST;
    let kick = 0;
    if (f.needle === 'recording') {
      const k = 1 - Math.exp(-f.value / CLIMB_SCALE);
      const swing = SWING_MIN + (SWING_MAX - SWING_MIN) * k;
      target = NEEDLE_REST + 6 + (NEEDLE_FULL - NEEDLE_REST - 10) * k + Math.sin(this.time * Math.PI * Math.max(2, f.tickHz * 0.5)) * swing;
      kick = f.ticks * TICK_KICK;
    } else if (f.needle === 'dormant') {
      this.twitchIn -= dt;
      if (this.twitchIn <= 0) {
        const near = f.distance === null ? 0 : Math.max(0, Math.min(1, 1 - f.distance / 16));
        const amp = TWITCH_FAR + (TWITCH_NEAR - TWITCH_FAR) * near;
        this.twitchTarget = TWITCH_OFFSET + (Math.random() * 2 - 1) * amp;
        // Irregular: mostly quick flicks, now and then a held pause.
        this.twitchIn = Math.random() < 0.2 ? 0.25 + Math.random() * 0.3 : 0.05 + Math.random() * 0.1;
      }
      target = NEEDLE_REST + Math.max(0, this.twitchTarget);
    }
    // Spring toward the target, never past the stops.
    const step = Math.min(dt, 1 / 30);
    let left = dt;
    while (left > 1e-6) {
      const h = Math.min(step, left);
      left -= h;
      const acc = NEEDLE_K * (target - this.angle) - 2 * NEEDLE_ZETA * Math.sqrt(NEEDLE_K) * this.angVel;
      this.angVel += acc * h;
      this.angle += this.angVel * h;
    }
    this.angVel += kick * 30;
    if (this.angle < NEEDLE_REST) {
      this.angle = NEEDLE_REST;
      if (this.angVel < 0) this.angVel *= -0.25;
    }
    if (this.angle > NEEDLE_FULL + 3) {
      this.angle = NEEDLE_FULL + 3;
      if (this.angVel > 0) this.angVel *= -0.25;
    }
    this.needlePivot.rotation.z = -this.angle * DEG;
  }

  private updateSlip(): void {
    const m = this.slipMesh;
    if (!m) return;
    const t = this.time - this.slipAt;
    if (t < 0 || t > SLIP_PRINT + SLIP_HOLD + SLIP_FALL) {
      m.visible = false;
      return;
    }
    m.visible = true;
    if (t < SLIP_PRINT) {
      // Printed a line at a time, in small jerks, like a strip printer.
      const p = Math.floor((t / SLIP_PRINT) * 9) / 9;
      this.slipGroup.position.set(0, BODY_H / 2 - this.slipH * (1 - p), -0.006);
      this.slipGroup.rotation.set(0, 0, 0);
    } else if (t < SLIP_PRINT + SLIP_HOLD) {
      // Up and readable, curled a touch toward the eye.
      this.slipGroup.position.set(0, BODY_H / 2, -0.006);
      this.slipGroup.rotation.set(0.25, 0, 0.02);
    } else {
      // Torn off: it drops away to the right.
      const p = (t - SLIP_PRINT - SLIP_HOLD) / SLIP_FALL;
      this.slipGroup.position.set(p * 0.08, BODY_H / 2 + p * 0.02 - p * p * 0.25, -0.006 + p * 0.03);
      this.slipGroup.rotation.set(0.25 + p * 0.8, 0, 0.02 - p * 1.2);
    }
  }
}
