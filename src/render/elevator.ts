// The elevator car at the landing: a small steel room you can stand in, with its own harsh light,
// two sliding doors that really open and close, a floor split into a BANK half and a DOWN half
// (painted words in the camcorder's pixel font, two colours), a door-hold button inside, and on the
// landing a call button and an indicator above the doors that shows where the car is.
//
// Everything is built in the car's own frame: origin at the middle of the doorway on the wall line,
// at floor height; x to the right as you walk in (DOWN is +x, BANK is -x); z OUT of the car (the car
// runs from z = 0 at the doors to z = -2 at its back wall), y up. The group's rotation and position
// put it on the floor plan, so the logic's car (sim/run.ts carGeometry) and this one coincide.

import * as THREE from 'three';
import type { CarGeometry, Side } from '../sim/run';
import { GeoBuilder, type RGB } from './geoBuilder';
import { rgb, scale } from './palette';
import { drawText, textWidth } from './pixelFont';
import { LIFT_DOOR_HEIGHT, LIFT_HALF_WIDTH } from './structure';

/** Inside height of the car (metres). */
export const CAR_HEIGHT = 2.5;
/** The car's front wall stands this far behind the landing's wall line: the doors slide in the gap. */
const FRONT = 0.09;
/** The door panels: their z range (inside the gap) and how far each slides when fully open. */
const PANEL_Z0 = -0.065;
const PANEL_Z1 = -0.03;
const PANEL_SLIDE = LIFT_HALF_WIDTH - 0.03;
/** Seconds the drawn doors take to open or close fully. */
const DOOR_SECONDS = 0.9;
/** Where the door-hold button is: on the car's front wall, to the DOWN side of the doors. */
export const HOLD_BUTTON = { x: 0.84, y: 1.15 };
/** Where the call button is: on the landing's wall, to the left of the doors as you face them. */
export const CALL_BUTTON = { x: -0.9, y: 1.12 };

const C = {
  wall: rgb(0xd4dde0),
  wallSeam: rgb(0x6e7a80),
  rail: rgb(0x8a959a),
  ceiling: rgb(0x2c3236),
  front: rgb(0xb4bfc3),
  plate: rgb(0x30363a),
  door: rgb(0xa9b4b8),
  doorEdge: rgb(0x272d30),
};

/** Floor paint: BANK in amber, DOWN in red. Warm both, so the tape's desaturation of cool hues spares them. */
const PAINT = {
  bank: { fill: '#e8a21c', ink: '#2a1a05', edge: '#1b1b18' },
  down: { fill: '#b8231c', ink: '#f6efe6', edge: '#1b1b18' },
};

/** The floor halves' paint brightness at rest, and while someone stands on it (pulsing up to max). */
const VOTE_GLOW = { rest: 0.16, on: 0.42, max: 0.68 };
/** The paint's brightness: the half someone stands on, the other half while one is chosen, and neither. */
const VOTE_PAINT = { on: 1, off: 0.5, none: 0.85 };

function paintHalf(word: string, p: { fill: string; ink: string; edge: string }, edgeOnLeft: boolean): THREE.CanvasTexture {
  // 1 m by 1.9 m at 48 px per metre. The word twice, stretched 2.5 times along the car like a road
  // marking: at the back, upright for someone walking in; by the doors, upright for someone facing
  // out. Both sit against the dividing line, so from the landing both halves show through the doorway.
  const w = 48;
  const h = 92;
  const c = document.createElement('canvas');
  c.width = w;
  c.height = h;
  const g = c.getContext('2d');
  if (g) {
    g.fillStyle = p.fill;
    g.fillRect(0, 0, w, h);
    // A hazard edge along the dividing line, a dark line at the wall.
    const ex = edgeOnLeft ? 0 : w - 3;
    for (let y = 0; y < h; y += 6) {
      g.fillStyle = (y / 6) % 2 === 0 ? '#f2d43a' : '#151515';
      g.fillRect(ex, y, 3, 6);
    }
    g.fillStyle = p.edge;
    g.fillRect(edgeOnLeft ? w - 2 : 0, 0, 2, h);
    g.fillRect(0, 0, w, 2);
    const tw = textWidth(word);
    const tmp = document.createElement('canvas');
    tmp.width = tw;
    tmp.height = 7;
    const tg = tmp.getContext('2d');
    if (tg) {
      tg.fillStyle = p.ink;
      drawText(tg, word, 0, 0);
      g.imageSmoothingEnabled = false;
      const th = 18;
      const sx = edgeOnLeft ? 6 : w - 6 - tw;
      // Canvas top is the back of the car.
      g.drawImage(tmp, sx, 14, tw, th);
      g.save();
      g.translate(w, h);
      g.rotate(Math.PI);
      // Rotated half a turn: the dividing line is now on the other side.
      g.drawImage(tmp, edgeOnLeft ? w - 6 - tw : 6, 12, tw, th);
      g.restore();
    }
  }
  const t = new THREE.CanvasTexture(c);
  t.magFilter = THREE.NearestFilter;
  t.minFilter = THREE.NearestFilter;
  t.generateMipmaps = false;
  t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

/** The indicator above the doors: dark glass, amber LED characters. */
class Indicator {
  readonly texture: THREE.CanvasTexture;
  private readonly canvas: HTMLCanvasElement;
  private text = '\u0000';

  constructor() {
    this.canvas = document.createElement('canvas');
    this.canvas.width = 26;
    this.canvas.height = 11;
    this.texture = new THREE.CanvasTexture(this.canvas);
    this.texture.magFilter = THREE.NearestFilter;
    this.texture.minFilter = THREE.NearestFilter;
    this.texture.generateMipmaps = false;
    this.texture.colorSpace = THREE.SRGBColorSpace;
    this.show('', false, 0);
  }

  /** `label` up to two characters; `arrow` -1 down, 1 up, 0 none; `lit` bright, else a faint glow. */
  show(label: string, lit: boolean, arrow: -1 | 0 | 1): void {
    const key = `${label}|${lit}|${arrow}`;
    if (key === this.text) return;
    this.text = key;
    const g = this.canvas.getContext('2d');
    if (!g) return;
    const w = this.canvas.width;
    g.fillStyle = '#0b0605';
    g.fillRect(0, 0, w, this.canvas.height);
    // Unlit segments show faintly, like a real LED panel.
    g.fillStyle = '#2a0f06';
    drawText(g, '▼', 2, 2);
    drawText(g, '88', 10, 2);
    g.fillStyle = lit ? '#ffb02a' : '#7a3a12';
    if (arrow !== 0) drawText(g, arrow < 0 ? '▼' : '▲', 2, 2);
    const lw = textWidth(label);
    drawText(g, label, 10 + Math.floor((11 - lw) / 2), 2);
    this.texture.needsUpdate = true;
  }

  get shown(): string {
    return this.text.split('|')[0] ?? '';
  }
}

export interface ElevatorStatus {
  /** 0 shut .. 1 open, as drawn. */
  doors: number;
  indicator: string;
  vote: Side | null;
  votes: { bank: number; down: number };
  callLit: boolean;
  holdLit: boolean;
}

export class ElevatorView {
  readonly group = new THREE.Group();
  private readonly left: THREE.Mesh;
  private readonly right: THREE.Mesh;
  private readonly bankMat: THREE.MeshLambertMaterial;
  private readonly downMat: THREE.MeshLambertMaterial;
  private readonly callMat: THREE.MeshBasicMaterial;
  private readonly holdMat: THREE.MeshBasicMaterial;
  private readonly panelMat: THREE.MeshBasicMaterial;
  private readonly indicator = new Indicator();
  private doorAmount = 0;
  private doorTarget = 0;
  private vote: Side | null = null;
  /** Everyone's votes: how many stand on each half (the local player's included). */
  private votes = { bank: 0, down: 0 };
  private callLit = false;
  private holdLit = false;
  private t = 0;

  constructor(readonly car: CarGeometry) {
    this.group.name = 'elevator';
    this.group.rotation.y = Math.atan2(-car.inX, -car.inZ);
    this.group.position.set(car.doorX, car.floorY, car.doorZ);

    // ---- The steel box: walls, ceiling, handrail, front wall with the doorway.
    const g = new GeoBuilder();
    const H = CAR_HEIGHT;
    const W = car.width / 2;
    const D = car.depth;
    const hw = LIFT_HALF_WIDTH;
    // Brushed steel in vertical panels, darker seams between them.
    const panels = (x0: number, z0: number, x1: number, z1: number, n: number, nx: number, nz: number): void => {
      for (let i = 0; i < n; i++) {
        const a = i / n;
        const b = (i + 1) / n;
        const shade = i % 2 === 0 ? 1 : 0.93;
        const xa = x0 + (x1 - x0) * a;
        const za = z0 + (z1 - z0) * a;
        const xb = x0 + (x1 - x0) * b;
        const zb = z0 + (z1 - z0) * b;
        const lo = scale(C.wall, 0.78 * shade);
        const hi = scale(C.wall, shade);
        g.quad([xa, 0, za], [xb - xa, 0, zb - za], [0, H, 0], [lo, lo, hi, hi]);
        g.quad([xb - (xb - xa) * 0.02 + nx * 0.003, 0, zb - (zb - za) * 0.02 + nz * 0.003], [(xb - xa) * 0.02, 0, (zb - za) * 0.02], [0, H, 0], C.wallSeam);
      }
    };
    // Back wall (faces +z), left wall (faces +x), right wall (faces -x): quads wind so they face inward.
    panels(-W, -D, W, -D, 4, 0, 1);
    panels(-W, -FRONT, -W, -D, 3, 1, 0);
    panels(W, -D, W, -FRONT, 3, -1, 0);
    // Front wall inside, either side of the doorway and over it (faces -z).
    const front = (x0: number, x1: number, y0: number, y1: number, c: RGB): void => g.quad([x1, y0, -FRONT], [x0 - x1, 0, 0], [0, y1 - y0, 0], c);
    front(-W, -hw, 0, H, C.front);
    front(hw, W, 0, H, C.front);
    front(-hw, hw, LIFT_DOOR_HEIGHT, H, scale(C.front, 0.9));
    // Jambs: the sides and head of the doorway through the wall gap, so you never see into the pocket.
    g.box([-hw - 0.02, 0, -FRONT], [-hw, LIFT_DOOR_HEIGHT, 0], C.doorEdge);
    g.box([hw, 0, -FRONT], [hw + 0.02, LIFT_DOOR_HEIGHT, 0], C.doorEdge);
    g.box([-hw, LIFT_DOOR_HEIGHT, -FRONT], [hw, LIFT_DOOR_HEIGHT + 0.02, 0], C.doorEdge);
    // Ceiling (faces down) and a kick strip round the floor.
    g.quad([-W, H, -D], [2 * W, 0, 0], [0, 0, D - FRONT], C.ceiling);
    g.box([-W, 0, -D], [W, 0.12, -D + 0.02], C.doorEdge);
    g.box([-W, 0, -D], [-W + 0.02, 0.12, -FRONT], C.doorEdge);
    g.box([W - 0.02, 0, -D], [W, 0.12, -FRONT], C.doorEdge);
    // Handrail along the back and both sides.
    g.box([-W + 0.08, 0.92, -D + 0.05], [W - 0.08, 0.97, -D + 0.1], C.rail);
    g.box([-W + 0.05, 0.92, -D + 0.08], [-W + 0.1, 0.97, -0.35], C.rail);
    g.box([W - 0.1, 0.92, -D + 0.08], [W - 0.05, 0.97, -0.35], C.rail);
    // Button plates: inside (door hold) and on the landing (call).
    g.box([HOLD_BUTTON.x - 0.09, HOLD_BUTTON.y - 0.3, -FRONT - 0.015], [HOLD_BUTTON.x + 0.09, HOLD_BUTTON.y + 0.3, -FRONT], C.plate);
    g.box([CALL_BUTTON.x - 0.08, CALL_BUTTON.y - 0.16, 0], [CALL_BUTTON.x + 0.08, CALL_BUTTON.y + 0.16, 0.015], C.plate);
    // The indicator's housing on the landing, and its twin over the doors inside.
    g.box([-0.52, 2.44, 0], [0.52, 2.94, 0.02], C.plate);
    g.box([-0.3, LIFT_DOOR_HEIGHT + 0.03, -FRONT - 0.012], [0.3, LIFT_DOOR_HEIGHT + 0.23, -FRONT], C.plate);
    // Harsh cold light: the shell glows a little on its own, so the car is brighter than the landing.
    const shell = new THREE.Mesh(g.build(), new THREE.MeshLambertMaterial({ vertexColors: true, emissive: 0x56626a }));
    shell.name = 'car-shell';
    this.group.add(shell);

    // ---- The light: one bright panel filling most of the ceiling.
    this.panelMat = new THREE.MeshBasicMaterial({ color: 0xffffff });
    const panel = new THREE.Mesh(new THREE.PlaneGeometry(1.3, 1.1).rotateX(Math.PI / 2), this.panelMat);
    panel.position.set(0, H - 0.005, -D / 2 - FRONT / 2);
    panel.name = 'car-light';
    this.group.add(panel);

    // ---- The floor: BANK (left walking in, -x) and DOWN (right, +x).
    const half = (word: string, p: typeof PAINT.bank, x: number, edgeOnLeft: boolean): THREE.MeshLambertMaterial => {
      const tex = paintHalf(word, p, edgeOnLeft);
      const mat = new THREE.MeshLambertMaterial({ map: tex, emissive: 0xffffff, emissiveMap: tex, emissiveIntensity: VOTE_GLOW.rest });
      const m = new THREE.Mesh(new THREE.PlaneGeometry(W, D - FRONT).rotateX(-Math.PI / 2), mat);
      m.position.set(x, 0.004, -(D + FRONT) / 2);
      // Its glow is driven here (the vote, the blink), not by applyLighting.
      m.userData.ownLight = true;
      this.group.add(m);
      return mat;
    };
    this.bankMat = half('BANK', PAINT.bank, -W / 2, false);
    this.downMat = half('DOWN', PAINT.down, W / 2, true);

    // ---- The doors: two steel panels meeting in the middle, sliding into the wall.
    const doorGeo = (sign: number): THREE.BufferGeometry => {
      const d = new GeoBuilder();
      const x0 = sign < 0 ? -hw : 0;
      const x1 = sign < 0 ? 0 : hw;
      d.box([x0, 0, PANEL_Z0], [x1, LIFT_DOOR_HEIGHT, PANEL_Z1], C.door);
      // The meeting edge: a dark rubber strip.
      const ex = sign < 0 ? -0.025 : 0;
      d.box([ex, 0, PANEL_Z1 - 0.004], [ex + 0.025, LIFT_DOOR_HEIGHT, PANEL_Z1 + 0.003], C.doorEdge);
      d.box([ex, 0, PANEL_Z0 - 0.003], [ex + 0.025, LIFT_DOOR_HEIGHT, PANEL_Z0 + 0.004], C.doorEdge);
      return d.build();
    };
    const doorMat = new THREE.MeshLambertMaterial({ vertexColors: true, emissive: 0x1c2224 });
    this.left = new THREE.Mesh(doorGeo(-1), doorMat);
    this.right = new THREE.Mesh(doorGeo(1), doorMat);
    this.left.name = 'car-door';
    this.right.name = 'car-door';
    this.group.add(this.left, this.right);

    // ---- Buttons and indicators: self-lit.
    this.holdMat = new THREE.MeshBasicMaterial({ color: 0x4a4f50 });
    const hold = new THREE.Mesh(new THREE.PlaneGeometry(0.1, 0.1).rotateY(Math.PI), this.holdMat);
    hold.position.set(HOLD_BUTTON.x, HOLD_BUTTON.y, -FRONT - 0.017);
    this.group.add(hold);
    this.callMat = new THREE.MeshBasicMaterial({ color: 0x4a4f50 });
    const call = new THREE.Mesh(new THREE.PlaneGeometry(0.1, 0.1), this.callMat);
    call.position.set(CALL_BUTTON.x, CALL_BUTTON.y, 0.017);
    this.group.add(call);
    const indMat = new THREE.MeshBasicMaterial({ map: this.indicator.texture, color: 0xffffff });
    const ind = new THREE.Mesh(new THREE.PlaneGeometry(0.96, 0.406), indMat);
    ind.position.set(0, 2.69, 0.022);
    ind.name = 'car-indicator';
    this.group.add(ind);
    const indIn = new THREE.Mesh(new THREE.PlaneGeometry(0.44, 0.186).rotateY(Math.PI), indMat);
    indIn.position.set(0, LIFT_DOOR_HEIGHT + 0.13, -FRONT - 0.014);
    this.group.add(indIn);

    this.placeDoors();
    this.group.updateMatrixWorld(true);
  }

  /** Doors open or shut. `instant` jumps there (a new floor, a new run). */
  setDoors(open: boolean, instant = false): void {
    this.doorTarget = open ? 1 : 0;
    if (instant) {
      this.doorAmount = this.doorTarget;
      this.placeDoors();
    }
  }

  setIndicator(label: string, lit: boolean, arrow: -1 | 0 | 1): void {
    this.indicator.show(label, lit, arrow);
  }

  setVote(side: Side | null): void {
    this.setVotes(side, side === 'bank' ? 1 : 0, side === 'down' ? 1 : 0);
  }

  /** The local player's vote (it pulses) and how many of the crew stand on each half (they glow). */
  setVotes(mine: Side | null, bank: number, down: number): void {
    this.vote = mine;
    this.votes = { bank: Math.max(bank, mine === 'bank' ? 1 : 0), down: Math.max(down, mine === 'down' ? 1 : 0) };
  }

  setCallLit(on: boolean): void {
    this.callLit = on;
  }

  setHoldLit(on: boolean): void {
    this.holdLit = on;
  }

  /** Per frame. `light` 0..1 (a blink takes it down); `gain` the tape's glare on light panels. */
  update(dt: number, light: number, gain: number): void {
    this.t += dt;
    const step = dt / DOOR_SECONDS;
    if (this.doorAmount < this.doorTarget) this.doorAmount = Math.min(this.doorTarget, this.doorAmount + step);
    else if (this.doorAmount > this.doorTarget) this.doorAmount = Math.max(this.doorTarget, this.doorAmount - step);
    this.placeDoors();
    const pulse = 0.5 + 0.5 * Math.sin(this.t * 7);
    const glow = (side: Side): number => (this.vote === side ? VOTE_GLOW.on + (VOTE_GLOW.max - VOTE_GLOW.on) * pulse : this.votes[side] > 0 ? VOTE_GLOW.on : VOTE_GLOW.rest);
    const anyVote = this.votes.bank + this.votes.down > 0;
    const paint = (side: Side): number => (!anyVote ? VOTE_PAINT.none : this.votes[side] > 0 ? VOTE_PAINT.on : VOTE_PAINT.off);
    this.bankMat.emissiveIntensity = glow('bank') * light;
    this.downMat.emissiveIntensity = glow('down') * light;
    this.bankMat.color.setScalar(paint('bank'));
    this.downMat.color.setScalar(paint('down'));
    this.panelMat.color.setScalar(Math.max(0.03, light) * gain * 1.25);
    this.callMat.color.set(this.callLit ? 0xffb02a : 0xc9cfc6);
    this.holdMat.color.set(this.holdLit ? 0x8cff9a : 0xc9cfc6);
  }

  status(): ElevatorStatus {
    return { doors: this.doorAmount, indicator: this.indicator.shown, vote: this.vote, votes: { ...this.votes }, callLit: this.callLit, holdLit: this.holdLit };
  }

  private placeDoors(): void {
    // Eased, so the doors start and stop like a motor drives them.
    const a = this.doorAmount;
    const e = a * a * (3 - 2 * a);
    this.left.position.x = -PANEL_SLIDE * e;
    this.right.position.x = PANEL_SLIDE * e;
  }

  dispose(): void {
    this.group.parent?.remove(this.group);
    this.group.traverse((o) => {
      const mesh = o as THREE.Mesh;
      if (!mesh.isMesh) return;
      mesh.geometry.dispose();
      const mats = Array.isArray(mesh.material) ? mesh.material : [mesh.material];
      for (const m of mats) {
        for (const v of Object.values(m)) if (v instanceof THREE.Texture) v.dispose();
        m.dispose();
      }
    });
  }
}
